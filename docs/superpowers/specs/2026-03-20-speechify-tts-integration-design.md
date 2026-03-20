# Speechify TTS Integration Design

## Overview

Add Text-to-Speech functionality to Open Wispr via integration with the Speechify desktop app for macOS. This is the first TTS mode — a custom built-in TTS engine will replace it later. The integration has two features: manual read-aloud of history entries, and automatic echo of new dictations.

## Architecture

### New Files

- `OpenWhisper/TTS/SpeechifyService.swift` — `@MainActor` CGEvent key simulation for Speechify control
- `OpenWhisper/TTS/EchoModeController.swift` — `@MainActor` NSPanel management for the Echo Mode floating panel
- `OpenWhisper/TTS/EchoModeState.swift` — `@MainActor @Observable` state tracking for Echo Mode
- `OpenWhisper/TTS/TTSSettings.swift` — TTS-related @AppStorage keys and enums (TTSMode, DockPosition)

### Modified Files

- `OpenWhisper/Views/SettingsView.swift` — New "Text to Speech" settings section
- `OpenWhisper/Views/HistoryView.swift` — Read button on entries in text/hybrid views
- `OpenWhisper/Views/HighlightedTextView.swift` — Add `selectAll()` method, modify for programmatic selection support
- `OpenWhisper/AppState.swift` — Integrate echo mode auto-read on new entry, pause Speechify on recording start, add `isMainWindowVisible` property

Note: `project.yml` does not need modification — xcodegen auto-discovers all Swift files under `OpenWhisper/`.

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
- Disabled during active recording or transcription (to prevent backtick interference with recording flow)

### Behavior

When pressed:
1. Programmatically select all text in that entry's `NSTextView` (the `HighlightedTextView`)
2. Make the `NSTextView` first responder in its window
3. Wait 50ms for the Accessibility API to register the selection
4. Simulate backtick keypress via CGEvent → triggers Speechify to read the selected text

### Required Changes to HighlightedTextView

The current `HighlightedTextView` has `isSelectable = false` and a `ClickOverlayView` that intercepts all mouse events via `hitTest`, blocking Accessibility API traversal. Speechify reads selected text via `kAXSelectedTextAttribute` on the focused element, so the text view must be selectable and accessible.

Required modifications to `HighlightedTextNSView`:

1. **Add a public `selectAllText()` method** that:
   - Temporarily sets `textView.isSelectable = true`
   - Sets `selectedRange` to the full text range
   - Makes the text view first responder via `window?.makeFirstResponder(textView)`
   - Note: the text view stays selectable until the Speechify read completes; a follow-up call or timer can reset it

2. **Keep `ClickOverlayView` as-is** for normal word-tap playback. The overlay does not need to be removed — `selectAllText()` programmatically sets the selection on the underlying `NSTextView` without going through hit-testing. Speechify accesses `kAXSelectedTextAttribute` on the `NSTextView` directly via the Accessibility API regardless of the overlay.

3. **Expose the method through the `NSViewRepresentable` bridge** by adding a coordinator or callback so the parent SwiftUI view can trigger `selectAllText()`.

## Feature 2: Echo Mode

### EchoModeController

`@MainActor` class managing a floating `NSPanel`, following the same pattern as the existing `OverlayController`:

- Panel style: header bar with green status dot + "Echo Mode" label, timestamp, close button. Body contains an `NSTextView` showing the most recent transcription.
- Compact, fixed-size panel
- **The panel must have `canBecomeKey` returning `true`** so the `NSTextView` inside it can become first responder and Speechify can query the selected text via Accessibility API. This differs from `RecordingOverlayPanel` which returns `false`.
- The panel should still be `isFloatingPanel = true` and use `.nonactivatingPanel` style mask so it doesn't steal activation from other apps, but it needs key window capability for the text selection to work.

### Docking & Dragging

- Starts anchored near the chosen screen edge per `echoModeDockPosition` setting
- User can drag it anywhere on screen freely (panel's `isMovableByWindowBackground = true`)
- Resets to dock position when Echo Mode is toggled off and back on

### Panel Visibility Rules

- Shown when: Echo Mode is enabled AND TTS mode is `.speechify` AND the main window is NOT visible
- Hidden when: the main window is visible (reappears when main window closes, if Echo Mode is still active)
- `EchoModeController` observes `AppState.isMainWindowVisible` to toggle panel visibility

### Main Window Visibility Tracking

Add `isMainWindowVisible: Bool` property to `AppState`, driven by `NSWindow.didBecomeKeyNotification` and `NSWindow.willCloseNotification` (or `NSWindow.didOrderOffScreenNotification` / `NSWindow.didOrderOnScreenNotification`). The existing `AppDelegate` already listens to some of these notifications for dock icon visibility — extend or mirror that pattern.

### Auto-Read Flow (new transcription completes)

1. Update the panel's text content with the new transcription entry
2. Make the panel key and the `NSTextView` first responder
3. Select all text in the panel's `NSTextView`
4. Wait 50ms for the Accessibility API to register the selection
5. Simulate backtick keypress via CGEvent → Speechify reads the selected text

### Dictation Pause Flow (recording starts)

1. Simulate Shift+backtick keypress via CGEvent → pauses Speechify playback
2. Proceed with normal recording flow

Integration point: `AppState.startRecording()` — add the pause call before existing recording logic, gated on `ttsMode == .speechify` (not gated on `echoModeEnabled`, because the user may have triggered a manual read via the history button and then started recording — Speechify should be paused regardless).

### EchoModeState

`@MainActor @Observable` class. Reads initial values from `@AppStorage` on init. `EchoModeController` reads from this state; settings UI writes to both `@AppStorage` and this state.

```swift
@MainActor
@Observable
class EchoModeState {
    var isActive: Bool = false
    var dockPosition: DockPosition = .bottom
    var currentEntry: TranscriptionEntry?
    /// Tracks user's last drag position so the panel can be restored after hide/show.
    var lastUserPosition: NSPoint? = nil
}
```

## SpeechifyService

`@MainActor` concrete service (no protocol) with two CGEvent methods, matching `PasteService` pattern:

```swift
@MainActor
class SpeechifyService {
    /// Simulate backtick key (kVK_ANSI_Grave, keycode 50) — triggers Speechify read
    func triggerRead() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Logger.tts.warning("Failed to create CGEventSource for triggerRead")
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 50, keyDown: true)
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 50, keyDown: false)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Simulate Shift+backtick (kVK_ANSI_Grave + Shift) — pauses Speechify
    func pausePlayback() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Logger.tts.warning("Failed to create CGEventSource for pausePlayback")
            return
        }
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
[History View] --read button--> select text in entry's NSTextView
                                  --> wait 50ms
                                  --> SpeechifyService.triggerRead()

[New Transcription] --echo mode--> EchoModeController updates panel text
                                    --> make panel key, text view first responder
                                    --> select all text
                                    --> wait 50ms
                                    --> SpeechifyService.triggerRead()

[Start Recording] --tts active--> SpeechifyService.pausePlayback()
                                    --> normal recording flow
```

## Out of Scope

- Custom built-in TTS engine (future work)
- TTS provider protocol/abstraction (not needed — Speechify is throwaway, future TTS will be completely different)
- Audio playback through the app itself (Speechify handles all audio)
- Speechify installation detection or health checks
