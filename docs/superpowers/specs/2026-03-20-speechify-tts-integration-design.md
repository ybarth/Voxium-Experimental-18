# Speechify TTS Integration Design

## Overview

Add Text-to-Speech functionality to Open Wispr via integration with the Speechify desktop app for macOS. This is the first TTS mode — a custom built-in TTS engine will replace it later. The integration has two features: manual read-aloud of history entries, and automatic echo of new dictations.

## Architecture

### New Files

- `OpenWhisper/TTS/SpeechifyService.swift` — CGEvent key simulation for Speechify control
- `OpenWhisper/TTS/EchoModeController.swift` — NSPanel management for the Echo Mode floating panel
- `OpenWhisper/TTS/EchoModeState.swift` — State tracking for Echo Mode (active, dock position, current entry)
- `OpenWhisper/TTS/TTSSettings.swift` — TTS-related @AppStorage keys and enums (TTSMode, DockPosition)

### Modified Files

- `OpenWhisper/Views/SettingsView.swift` — New "Text to Speech" settings section
- `OpenWhisper/Views/HistoryView.swift` — Read button on entries in text/hybrid views
- `OpenWhisper/AppState.swift` — Integrate echo mode auto-read on new entry, pause Speechify on recording start, observe history window open/closed state
- `project.yml` — Add new source files

## Settings

### TTS Section in SettingsView

Positioned after existing settings sections. Contains:

- **TTS Mode picker**: Dropdown with options `.off` and `.speechify`. When `.speechify` is selected, a note explains the user must have Speechify desktop app installed with the backtick key configured as the read shortcut.
- **Echo Mode toggle**: Only visible when TTS mode is not `.off`. Includes a dock position picker (top / bottom / left / right, defaulting to bottom).

### Storage

`@AppStorage` keys:
- `ttsMode` (String, default: `"off"`) — current TTS provider
- `echoModeEnabled` (Bool, default: `false`) — whether Echo Mode is active
- `echoModeDockPosition` (String, default: `"bottom"`) — screen edge for the Echo Mode panel

### Enums

```swift
enum TTSMode: String, CaseIterable {
    case off
    case speechify
}

enum DockPosition: String, CaseIterable {
    case top, bottom, left, right
}
```

## Feature 1: Read Transcription Button

### Appearance

- SF Symbol `speaker.wave.2.fill` icon button in the header row of each history entry, top-right, next to the timestamp
- Only visible in **text** and **hybrid** view modes (not bars/waveform)
- Only visible when TTS mode is `.speechify`

### Behavior

When pressed:
1. Programmatically select all text in that entry's `NSTextView` (the `HighlightedTextView`)
2. Simulate backtick keypress via CGEvent → triggers Speechify to read the selected text

### Implementation Notes

- The `HighlightedTextView` uses an `NSTextView` — selecting all text is `textView.selectAll(nil)` or setting `selectedRange` to the full range
- The text view must be first responder for Speechify to detect the selection
- The entry's NSTextView needs to support programmatic selection (currently it may be optimized for display-only with a click overlay for word highlighting)

## Feature 2: Echo Mode

### EchoModeController

Manages a floating `NSPanel`, following the same pattern as the existing `OverlayController`:
- `NSPanel` configured as floating, non-activating (doesn't steal focus)
- Panel style: header bar with green status dot + "Echo Mode" label, timestamp, close button. Body contains an `NSTextView` showing the most recent transcription.
- Compact, fixed-size panel (not full-width strip)

### Docking & Dragging

- Starts anchored near the chosen screen edge per `echoModeDockPosition` setting
- User can drag it anywhere on screen freely
- Resets to dock position when Echo Mode is toggled off and back on

### Panel Visibility Rules

- Shown when: Echo Mode is enabled AND TTS mode is `.speechify` AND the main history window is NOT open
- Hidden when: the main history window is open (reappears when history window closes, if Echo Mode is still active)
- `EchoModeController` observes the history window's open/closed state to toggle panel visibility

### Auto-Read Flow (new transcription completes)

1. Update the panel's text content with the new transcription entry
2. Select all text in the panel's `NSTextView`
3. Simulate backtick keypress via CGEvent → Speechify reads the selected text

### Dictation Pause Flow (recording starts)

1. Simulate Shift+backtick keypress via CGEvent → pauses Speechify playback
2. Proceed with normal recording flow

Integration point: `AppState.startRecording()` — add the pause call before existing recording logic, gated on `ttsMode == .speechify && echoModeEnabled`.

### EchoModeState

```swift
@Observable
class EchoModeState {
    var isActive: Bool = false
    var dockPosition: DockPosition = .bottom
    var currentEntry: TranscriptionEntry?
    var panelFrame: NSRect = .zero
}
```

## SpeechifyService

Concrete service (no protocol) with two CGEvent methods:

```swift
class SpeechifyService {
    /// Simulate backtick key (kVK_ANSI_Grave, keycode 50) — triggers Speechify read
    func triggerRead() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 50, keyDown: true)
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 50, keyDown: false)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Simulate Shift+backtick (kVK_ANSI_Grave + Shift) — pauses Speechify
    func pausePlayback() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 50, keyDown: true)
        keyDown?.flags = .maskShift
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 50, keyDown: false)
        keyUp?.flags = .maskShift
        keyUp?.post(tap: .cghidEventTap)
    }
}
```

## Data Flow

```
[History View] --read button--> SpeechifyService.triggerRead()
                                  (after selecting text in entry's NSTextView)

[New Transcription] --echo mode--> EchoModeController updates panel text
                                    --> select all text
                                    --> SpeechifyService.triggerRead()

[Start Recording] --echo mode--> SpeechifyService.pausePlayback()
                                  --> normal recording flow
```

## Out of Scope

- Custom built-in TTS engine (future work)
- TTS provider protocol/abstraction (not needed — Speechify is throwaway, future TTS will be completely different)
- Audio playback through the app itself (Speechify handles all audio)
- Speechify installation detection or health checks
