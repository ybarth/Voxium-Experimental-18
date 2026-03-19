# Quad — Session Log

## 2026-03-19: Wispr Flow-style Features

### What We Did

Implemented 5 features to make Open Wispr feel more like Wispr Flow, plus a follow-up fix and redesign.

---

### Feature 1: Floating Pill with Idle State

The overlay is now a persistent floating pill at the bottom-center of the screen instead of appearing/disappearing on each recording.

- **OverlayState** — Added `.idle` phase. The overlay defaults to idle instead of hidden.
- **OverlayController** — Panel is created eagerly in `init()` instead of lazily. New `updateForPhase(_:)` animates between sizes: idle pill (60×36) ↔ expanded (280×80). `ignoresMouseEvents` is toggled per phase (false in idle for right-click menu, true otherwise).
- **RecordingOverlayContent** — New idle view: frosted-glass capsule with mic icon. Added `.animation(.spring)` for smooth SwiftUI content transitions between phases.
- **AppState** — After recording/transcribing/cancelling, returns to `.idle` instead of `.hidden`. Added `@AppStorage("showIdlePill")` toggle and `setShowIdlePill(_:)` method. Removed all direct `overlayController?.show()`/`dismiss()` patterns in favor of setting phase + calling `updateForPhase()`.

### Feature 2: Push-to-Talk as a Separate Hotkey

Push-to-talk and toggle are **not** alternative modes — they are two independent hotkeys that both work simultaneously.

- **HotkeyNames** — Added `.pushToTalkRecording` (no default shortcut; user assigns in Settings).
- **AppState** — Registers both hotkeys at init:
  - `.toggleRecording`: `onKeyUp` → `toggleRecording()`
  - `.pushToTalkRecording`: `onKeyDown` → `startRecording()` (with key-repeat guard), `onKeyUp` → `stopRecordingAndTranscribe()`
- **SettingsTabView** — Added "Push-to-Talk" shortcut recorder row in the Hotkeys section.
- **Deleted** `RecordingMode.swift` — the toggle/PTT picker approach was scrapped.

### Feature 3: Settings Confirmation Dialog

When navigating away from the Settings tab with unsaved hotkey changes, a confirmation dialog appears.

- **AppState** — Added `snapshotHotkeySettings()`, `hasUnsavedHotkeyChanges`, `revertHotkeyChanges()`, `acceptHotkeyChanges()`. Tracks original values for toggle, cancel, and PTT shortcuts.
- **MainWindowView** — Tab selection uses a custom `Binding` that intercepts navigation away from `.settings`. Shows an alert with "Keep Changes" / "Revert" / "Cancel". Window close auto-accepts via `.onDisappear`.
- **SettingsTabView** — Calls `snapshotHotkeySettings()` in `.onAppear` and `acceptHotkeyChanges()` in `.onDisappear`.

### Feature 4: Non-Standard Keyboard Support

- **ShortcutRecorder** — Added F1–F20 and all numpad key cases to `Key.displayString`.
- Switched from `TISCopyCurrentKeyboardInputSource()` to `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()` for stable display across non-Latin input sources.

### Feature 5: Keyboard Shortcut Conflict Detection

- **New file `SystemShortcutNames.swift`** — Maps ~30 well-known macOS symbolic hotkey IDs to names (Mission Control, Spotlight, etc.). Reads `com.apple.symbolichotkeys` from UserDefaults to match key+modifiers to system function names.
- **ShortcutRecorder** — After capturing a shortcut, checks for system hotkey conflicts and main menu conflicts. Shows an orange warning label below the recorder. Conflicts are warnings, not blockers.

### Feature 6: Right-Click Context Menu on Idle Pill

Right-clicking the floating pill opens a context menu with:

- **Paste Last Dictation** — pastes the most recent history entry
- **Model** — submenu with picker showing all models (checkmark on current)
- **Microphone** — submenu listing all audio input devices (System Default + enumerated devices)
- **Settings** / **History** — opens the main window navigated to that tab

Supporting changes:
- **AudioRecorder** — Added CoreAudio device enumeration (`availableInputDevices()`), `selectedDeviceUID` persisted via UserDefaults, applied to `AVAudioEngine` input node before recording via `kAudioOutputUnitProperty_CurrentDevice`.
- **AppState** — Added `desiredTab: AppTab?` and `showTab(_:)` helper.
- **MainWindowView** — Observes `desiredTab` via `.onChange` to switch tabs when the window appears.
- **SettingsTabView** — Added Microphone picker section.
- **OverlayController** — Now takes `AppState` instead of separate `OverlayState` + `AudioRecorder`.
- **RecordingOverlayContent** — Now takes `AppState` for context menu access.

### Bug Fix: Push-to-Talk Shortcut Not Working After Assignment

**Root cause:** `ShortcutRecorder.stopRecording()` restored the *previous* enabled state of a shortcut. For PTT (which had no default), `isEnabled` returned `false` before recording, so `stopRecording()` called `KeyboardShortcuts.disable(.pushToTalkRecording)` — immediately unregistering the shortcut the user just set.

**Fix:** Changed `stopRecording()` to always re-enable the shortcut if one is currently set, instead of blindly restoring the old state. This also fixes the same latent bug for any hotkey assigned for the first time.

---

### Files Changed

| File | Changes |
|------|---------|
| `OpenWhisper/AppState.swift` | Hotkey registration for toggle+PTT, overlay lifecycle, settings snapshot, `desiredTab`, `showIdlePill` |
| `OpenWhisper/Audio/AudioRecorder.swift` | CoreAudio device enumeration, `selectedDeviceUID`, device selection on recording start |
| `OpenWhisper/Hotkey/HotkeyNames.swift` | Added `.pushToTalkRecording` |
| `OpenWhisper/Hotkey/SystemShortcutNames.swift` | **New** — system hotkey conflict detection |
| `OpenWhisper/Overlay/OverlayController.swift` | Eager panel creation, `updateForPhase()`, `ignoresMouseEvents` toggling, takes `AppState` |
| `OpenWhisper/Overlay/OverlayState.swift` | Added `.idle` phase |
| `OpenWhisper/Views/MainWindowView.swift` | Tab interception for unsaved changes, `desiredTab` observer |
| `OpenWhisper/Views/MenuBarMenuView.swift` | Minor cleanup |
| `OpenWhisper/Views/RecordingOverlayContent.swift` | Idle view with context menu, takes `AppState`, spring animation |
| `OpenWhisper/Views/SettingsTabView.swift` | PTT recorder, mic picker, overlay toggle, settings snapshot hooks |
| `OpenWhisper/Views/ShortcutRecorder.swift` | F-key/numpad display, conflict detection, ASCII-capable keyboard source, fixed enable/disable bug |
