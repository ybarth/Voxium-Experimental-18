# Speechify TTS Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Speechify desktop app integration with two features: manual read-aloud of history entries and automatic Echo Mode for new dictations.

**Architecture:** New `TTS/` directory with `SpeechifyService` (CGEvent key simulation), `EchoModeController` (floating NSPanel), `EchoModeState`, and `TTSSettings` (enums + @AppStorage). Modifications to `HistoryView` (read button), `SettingsView` (TTS section), `HighlightedTextView` (programmatic selection), and `AppState` (echo mode integration + pause on recording).

**Tech Stack:** SwiftUI, AppKit (NSPanel, NSTextView, CGEvent), Carbon.HIToolbox (key codes)

**Spec:** `docs/superpowers/specs/2026-03-20-speechify-tts-integration-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `OpenWhisper/TTS/TTSSettings.swift` | `TTSMode` and `DockPosition` enums |
| `OpenWhisper/TTS/SpeechifyService.swift` | CGEvent backtick/shift+backtick simulation |
| `OpenWhisper/TTS/EchoModeState.swift` | Observable state for Echo Mode panel |
| `OpenWhisper/TTS/EchoModeController.swift` | NSPanel lifecycle, docking, dragging |
| `OpenWhisper/TTS/EchoModePanel.swift` | NSPanel subclass (canBecomeKey = true) |
| `OpenWhisper/TTS/EchoModePanelContent.swift` | SwiftUI content for the Echo Mode panel |

### Modified Files
| File | Changes |
|------|---------|
| `OpenWhisper/Logging/TranscriptionLogger.swift:4-10` | Add `.tts` log category |
| `OpenWhisper/Views/HighlightedTextView.swift:30-31,57-59` | Add `selectAllText()` method, expose via bridge |
| `OpenWhisper/Views/SettingsView.swift:265` | Add "Text to Speech" section before build info |
| `OpenWhisper/Views/HistoryView.swift:184-196` | Add speaker icon button in entry header row |
| `OpenWhisper/AppState.swift:37-43,227,461` | Add SpeechifyService, EchoModeController, main window visibility, pause-on-record, echo-on-transcribe |
| `OpenWhisper/AppDelegate.swift:31-55` | Post main window visibility notifications that AppState observes |

---

### Task 1: TTSSettings — Enums and Storage Keys

**Files:**
- Create: `OpenWhisper/TTS/TTSSettings.swift`

- [ ] **Step 1: Create TTSSettings.swift with enums**

```swift
import Foundation

enum TTSMode: String, CaseIterable {
    case off
    case speechify

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .speechify: return "Speechify"
        }
    }
}

enum DockPosition: String, CaseIterable {
    case top, bottom, left, right

    var displayName: String {
        rawValue.capitalized
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/TTS/TTSSettings.swift
git commit -m "feat(tts): add TTSMode and DockPosition enums"
```

---

### Task 2: SpeechifyService — CGEvent Key Simulation

**Files:**
- Create: `OpenWhisper/TTS/SpeechifyService.swift`
- Reference: `OpenWhisper/Paste/PasteService.swift` (CGEvent pattern)

- [ ] **Step 1: Create SpeechifyService.swift**

```swift
import AppKit
import Carbon.HIToolbox

@MainActor
final class SpeechifyService {
    private let logger = TranscriptionLogger.shared

    /// Simulate backtick key (kVK_ANSI_Grave) to trigger Speechify read.
    func triggerRead() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            logger.error("Failed to create CGEventSource for triggerRead", category: .tts)
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Grave), keyDown: true)
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Grave), keyDown: false)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Simulate Shift+backtick to pause Speechify.
    func pausePlayback() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            logger.error("Failed to create CGEventSource for pausePlayback", category: .tts)
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Grave), keyDown: true)
        keyDown?.flags = .maskShift
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Grave), keyDown: false)
        keyUp?.flags = .maskShift
        keyUp?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 2: Add `.tts` log category**

In `OpenWhisper/Logging/TranscriptionLogger.swift`, add `case tts` to `LogCategory`:

```swift
enum LogCategory: String, CaseIterable {
    case general
    case download
    case server
    case transcription
    case model
    case tts
}
```

- [ ] **Step 3: Build to verify**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add OpenWhisper/TTS/SpeechifyService.swift OpenWhisper/Logging/TranscriptionLogger.swift
git commit -m "feat(tts): add SpeechifyService with CGEvent key simulation"
```

---

### Task 3: HighlightedTextView — Programmatic Selection Support

**Files:**
- Modify: `OpenWhisper/Views/HighlightedTextView.swift`

The `HighlightedTextView` currently has `isSelectable = false` and a `ClickOverlayView` blocking accessibility. We need to add a method to programmatically select all text and make the text view first responder, so Speechify can read it via the Accessibility API.

- [ ] **Step 1: Add `selectAllText()` to `HighlightedTextNSView`**

Add this public method to `HighlightedTextNSView` (after the existing `updateHighlight` method, around line 158):

```swift
/// Select all text for Speechify TTS integration.
/// Makes the text view selectable and first responder so the Accessibility API
/// can report the selected text to Speechify.
func selectAllText() {
    textView.isSelectable = true
    window?.makeFirstResponder(textView)
    textView.selectAll(nil)
}

/// Deselect text and restore non-selectable state.
func deselectAllText() {
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.isSelectable = false
}
```

- [ ] **Step 2: Expose selection trigger via the NSViewRepresentable bridge**

Add an `onSelectAll` callback to `HighlightedTextView` and a Coordinator to bridge it. Replace the struct definition and its methods:

```swift
struct HighlightedTextView: NSViewRepresentable {
    let text: String
    let activeWordIndex: Int
    let wordTimestamps: [WordTimestamp]
    let onWordTapped: ((Int) -> Void)?
    var lineLimit: Int? = nil
    /// Set to a non-nil closure to receive a reference to the select/deselect functions.
    var onSelectAllBridge: ((_ selectAll: @escaping () -> Void, _ deselectAll: @escaping () -> Void) -> Void)? = nil

    func makeNSView(context: Context) -> HighlightedTextNSView {
        let view = HighlightedTextNSView()
        view.setLineLimit(lineLimit)
        view.setText(text, timestamps: wordTimestamps)
        view.onWordTapped = onWordTapped
        // Provide the select/deselect closures to the parent
        onSelectAllBridge?({ view.selectAllText() }, { view.deselectAllText() })
        return view
    }

    func updateNSView(_ nsView: HighlightedTextNSView, context: Context) {
        nsView.onWordTapped = onWordTapped
        nsView.setLineLimit(lineLimit)
        nsView.updateHighlight(activeIndex: activeWordIndex, animated: true)
        // Re-provide closures in case the view was recreated
        onSelectAllBridge?({ nsView.selectAllText() }, { nsView.deselectAllText() })
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED (existing callers don't pass `onSelectAllBridge`, so default nil keeps them working)

- [ ] **Step 4: Commit**

```bash
git add OpenWhisper/Views/HighlightedTextView.swift
git commit -m "feat(tts): add programmatic text selection to HighlightedTextView"
```

---

### Task 4: Settings View — TTS Section

**Files:**
- Modify: `OpenWhisper/Views/SettingsView.swift`

- [ ] **Step 1: Add @AppStorage properties to SettingsView**

Add these properties inside `SettingsView` after the existing `@State` properties (after line 8):

```swift
@AppStorage("ttsMode") private var ttsMode: String = TTSMode.off.rawValue
@AppStorage("echoModeEnabled") private var echoModeEnabled: Bool = false
@AppStorage("echoModeDockPosition") private var echoModeDockPosition: String = DockPosition.bottom.rawValue
```

- [ ] **Step 2: Add TTS section to the Form**

Insert before the build info section (before the `Section` containing "Build 2026.03.20-A", around line 265):

```swift
Section("Text to Speech") {
    Picker("TTS Mode", selection: Binding(
        get: { TTSMode(rawValue: ttsMode) ?? .off },
        set: { ttsMode = $0.rawValue }
    )) {
        ForEach(TTSMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
        }
    }

    if TTSMode(rawValue: ttsMode) == .speechify {
        Text("Requires Speechify desktop app with backtick (`) configured as the read shortcut.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Echo Mode", isOn: $echoModeEnabled)

        if echoModeEnabled {
            Picker("Dock Position", selection: Binding(
                get: { DockPosition(rawValue: echoModeDockPosition) ?? .bottom },
                set: { echoModeDockPosition = $0.rawValue }
            )) {
                ForEach(DockPosition.allCases, id: \.self) { pos in
                    Text(pos.displayName).tag(pos)
                }
            }

            Text("Shows a floating panel with the latest transcription. Automatically reads new dictations aloud.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add OpenWhisper/Views/SettingsView.swift
git commit -m "feat(tts): add Text to Speech settings section"
```

---

### Task 5: Read Button in History View

**Files:**
- Modify: `OpenWhisper/Views/HistoryView.swift`

- [ ] **Step 1: Add @AppStorage and state for TTS**

Add these properties to `HistoryView` (after the existing `@State` properties, around line 30):

```swift
@AppStorage("ttsMode") private var ttsMode: String = TTSMode.off.rawValue
@State private var selectAllClosures: [UUID: () -> Void] = [:]
@State private var deselectAllClosures: [UUID: () -> Void] = [:]
```

- [ ] **Step 2: Add the read button in the entry header row**

In the `HStack` that contains the entry action buttons (around line 184, after the play/collapse button and before the copy button), add:

```swift
if TTSMode(rawValue: ttsMode) == .speechify && (viewMode == .text || viewMode == .hybrid) {
    Button {
        readEntryAloud(entry)
    } label: {
        Image(systemName: "speaker.wave.2.fill")
            .font(.caption)
    }
    .buttonStyle(.borderless)
    .help("Read aloud with Speechify")
    .disabled(appState.isRecording || appState.isTranscribing)
}
```

- [ ] **Step 3: Wire up `onSelectAllBridge` on `HighlightedTextView` instances**

Update the two `HighlightedTextView` usages in `entryContentView` (the non-expanded text and hybrid cases) to pass the bridge. In the `.text` case (around line 366):

```swift
HighlightedTextView(
    text: entry.text,
    activeWordIndex: -1,
    wordTimestamps: entry.wordTimestamps ?? [],
    onWordTapped: { startPlayback(for: entry, atWord: $0) },
    lineLimit: 4,
    onSelectAllBridge: { selectAll, deselectAll in
        selectAllClosures[entry.id] = selectAll
        deselectAllClosures[entry.id] = deselectAll
    }
)
```

Do the same for the hybrid case's `HighlightedTextView` (around line 437):

```swift
HighlightedTextView(
    text: entry.text,
    activeWordIndex: -1,
    wordTimestamps: entry.wordTimestamps ?? [],
    onWordTapped: { startPlayback(for: entry, atWord: $0) },
    lineLimit: 4,
    onSelectAllBridge: { selectAll, deselectAll in
        selectAllClosures[entry.id] = selectAll
        deselectAllClosures[entry.id] = deselectAll
    }
)
```

- [ ] **Step 4: Add `readEntryAloud` method**

Add this method to `HistoryView` (in the helpers section, around line 655):

```swift
private func readEntryAloud(_ entry: TranscriptionEntry) {
    guard let selectAll = selectAllClosures[entry.id] else { return }
    selectAll()

    // Wait 50ms for Accessibility API to register the selection, then trigger Speechify
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        appState.speechifyService.triggerRead()

        // Deselect after a short delay to clean up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            deselectAllClosures[entry.id]?()
        }
    }
}
```

Note: `appState.speechifyService` will be added in Task 7 when we modify AppState.

- [ ] **Step 5: Build to verify**

Run: `scripts/build.sh`
Expected: May not build yet (depends on `appState.speechifyService` from Task 7). That's OK — we'll verify the full build after Task 7.

- [ ] **Step 6: Commit**

```bash
git add OpenWhisper/Views/HistoryView.swift
git commit -m "feat(tts): add read-aloud button to history entries"
```

---

### Task 6: Echo Mode — Panel and Controller

**Files:**
- Create: `OpenWhisper/TTS/EchoModeState.swift`
- Create: `OpenWhisper/TTS/EchoModePanel.swift`
- Create: `OpenWhisper/TTS/EchoModePanelContent.swift`
- Create: `OpenWhisper/TTS/EchoModeController.swift`

- [ ] **Step 1: Create EchoModeState.swift**

```swift
import AppKit

@MainActor
@Observable
final class EchoModeState {
    var isActive: Bool = false
    var dockPosition: DockPosition = .bottom
    var currentEntry: TranscriptionEntry?
    /// Tracks user's drag position to persist across hide/show cycles.
    var lastUserPosition: NSPoint? = nil
}
```

- [ ] **Step 2: Create EchoModePanel.swift**

```swift
import AppKit

final class EchoModePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Must be true so the NSTextView inside can become first responder
    // and Speechify can read selected text via Accessibility API.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 3: Create EchoModePanelContent.swift**

```swift
import SwiftUI

struct EchoModePanelContent: View {
    let entry: TranscriptionEntry?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)

                Text("Echo Mode")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)

                Spacer()

                if let entry {
                    Text(relativeTime(from: entry.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial.opacity(0.5))

            Divider()

            // Text content
            if let entry {
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                Text("Waiting for transcription...")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private func relativeTime(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        return "\(hours)h ago"
    }
}
```

- [ ] **Step 4: Create EchoModeController.swift**

```swift
import AppKit
import SwiftUI

@MainActor
final class EchoModeController {
    private var panel: EchoModePanel?
    private let state: EchoModeState
    private let speechifyService: SpeechifyService
    private let logger = TranscriptionLogger.shared

    /// The NSTextView used for Speechify text selection in the echo panel.
    /// Positioned off-screen (not hidden via isHidden, which removes it from the accessibility tree).
    private var echoTextView: NSTextView?
    private var hostingView: NSHostingView<EchoModePanelContent>?

    private static let panelSize = NSSize(width: 380, height: 120)

    init(state: EchoModeState, speechifyService: SpeechifyService) {
        self.state = state
        self.speechifyService = speechifyService
    }

    // MARK: - Panel lifecycle

    func showPanel() {
        guard panel == nil else {
            panel?.orderFront(nil)
            return
        }

        let frame = dockFrame(for: state.dockPosition)
        let newPanel = EchoModePanel(contentRect: frame)

        // Create an off-screen NSTextView for Speechify text selection.
        // Do NOT use isHidden — hidden views are removed from the accessibility tree.
        let textView = NSTextView(frame: NSRect(x: -9999, y: -9999, width: 1, height: 1))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.alphaValue = 0
        newPanel.contentView?.addSubview(textView)
        echoTextView = textView

        let hosting = NSHostingView(
            rootView: EchoModePanelContent(
                entry: state.currentEntry,
                onClose: { [weak self] in self?.hidePanel() }
            )
        )
        newPanel.contentView?.addSubview(hosting, positioned: .below, relativeTo: textView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if let contentView = newPanel.contentView {
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }
        self.hostingView = hosting

        newPanel.orderFront(nil)
        self.panel = newPanel
        logger.info("Echo Mode panel shown", category: .tts)
    }

    func hidePanel() {
        if let panel {
            state.lastUserPosition = panel.frame.origin
        }
        panel?.orderOut(nil)
        panel = nil
        echoTextView = nil
        hostingView = nil
        logger.info("Echo Mode panel hidden", category: .tts)
    }

    /// Update the panel content and trigger Speechify read.
    func displayEntry(_ entry: TranscriptionEntry) {
        state.currentEntry = entry

        guard let panel else { return }

        // Update SwiftUI content via rootView property (avoids recreating the hosting view)
        hostingView?.rootView = EchoModePanelContent(
            entry: entry,
            onClose: { [weak self] in self?.hidePanel() }
        )

        // Select text in the off-screen text view and trigger Speechify
        if let textView = echoTextView {
            textView.string = entry.text
            panel.makeKey()
            panel.makeFirstResponder(textView)
            textView.selectAll(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.speechifyService.triggerRead()

                // Clean up selection after Speechify has grabbed it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                }
            }
        }

        logger.info("Echo Mode: reading entry \(entry.id)", category: .tts)
    }

    // MARK: - Docking

    func updateDockPosition(_ position: DockPosition) {
        state.dockPosition = position
        state.lastUserPosition = nil
        if let panel {
            let frame = dockFrame(for: position)
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    private func dockFrame(for position: DockPosition) -> NSRect {
        // Use last user position if available
        if let lastPos = state.lastUserPosition {
            return NSRect(origin: lastPos, size: Self.panelSize)
        }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = Self.panelSize
        let margin: CGFloat = 20

        let origin: NSPoint
        switch position {
        case .bottom:
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + margin
            )
        case .top:
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - margin
            )
        case .left:
            origin = NSPoint(
                x: visible.minX + margin,
                y: visible.midY - size.height / 2
            )
        case .right:
            origin = NSPoint(
                x: visible.maxX - size.width - margin,
                y: visible.midY - size.height / 2
            )
        }

        return NSRect(origin: origin, size: size)
    }
}
```

- [ ] **Step 5: Build to verify**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add OpenWhisper/TTS/EchoModeState.swift OpenWhisper/TTS/EchoModePanel.swift OpenWhisper/TTS/EchoModePanelContent.swift OpenWhisper/TTS/EchoModeController.swift
git commit -m "feat(tts): add Echo Mode panel, controller, and state"
```

---

### Task 7: AppState Integration — Wire Everything Together

**Files:**
- Modify: `OpenWhisper/AppState.swift`
- Modify: `OpenWhisper/AppDelegate.swift`

This is the orchestration task that connects all the pieces.

- [ ] **Step 1: Add main window visibility tracking to AppDelegate**

In `AppDelegate.swift`, post a custom notification when the main window opens/closes. Update the `windowDidClose` and `windowDidBecomeKey` methods:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Posted when the main window becomes visible or closes.
    static let mainWindowVisibilityChanged = Notification.Name("mainWindowVisibilityChanged")

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.showMainWindow()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowDidClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !(window is NSPanel),
              window.title == "OpenWhisper" || window.identifier?.rawValue == "main"
        else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasVisibleMainWindow = NSApplication.shared.windows.contains {
                !($0 is NSPanel) && $0.isVisible &&
                ($0.title == "OpenWhisper" || $0.identifier?.rawValue == "main")
            }
            if !hasVisibleMainWindow {
                NSApp.setActivationPolicy(.accessory)
            }
            NotificationCenter.default.post(name: Self.mainWindowVisibilityChanged, object: nil)
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !(window is NSPanel),
              window.title == "OpenWhisper" || window.identifier?.rawValue == "main"
        else { return }
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.post(name: Self.mainWindowVisibilityChanged, object: nil)
    }
}
```

- [ ] **Step 2: Add TTS properties and services to AppState**

Add these properties after the existing service declarations (around line 43):

```swift
let speechifyService = SpeechifyService()
let echoModeState = EchoModeState()
private(set) var echoModeController: EchoModeController?

@ObservationIgnored
@AppStorage("ttsMode") var ttsMode: String = TTSMode.off.rawValue

@ObservationIgnored
@AppStorage("echoModeEnabled") var echoModeEnabled: Bool = false

@ObservationIgnored
@AppStorage("echoModeDockPosition") var echoModeDockPosition: String = DockPosition.bottom.rawValue

/// Whether the main app window is currently visible.
var isMainWindowVisible: Bool = false
```

- [ ] **Step 3: Initialize echo mode controller and observers in init()**

Add at the end of `init()`, before the closing brace (before line 126):

```swift
// Initialize Echo Mode
echoModeController = EchoModeController(state: echoModeState, speechifyService: speechifyService)
syncEchoModeState()

// Observe main window visibility changes
NotificationCenter.default.addObserver(
    forName: AppDelegate.mainWindowVisibilityChanged,
    object: nil,
    queue: .main
) { [weak self] _ in
    guard let self else { return }
    Task { @MainActor in
        self.updateMainWindowVisibility()
        self.updateEchoModePanel()
    }
}
```

- [ ] **Step 4: Add echo mode helper methods**

Add these methods to AppState (at the end, before the closing brace):

```swift
// MARK: - Echo Mode

/// Sync EchoModeState from @AppStorage values.
func syncEchoModeState() {
    echoModeState.isActive = echoModeEnabled && TTSMode(rawValue: ttsMode) == .speechify
    echoModeState.dockPosition = DockPosition(rawValue: echoModeDockPosition) ?? .bottom
    updateEchoModePanel()
}

/// Show or hide the echo mode panel based on current state.
private func updateEchoModePanel() {
    if echoModeState.isActive && !isMainWindowVisible {
        echoModeController?.showPanel()
    } else {
        echoModeController?.hidePanel()
    }
}

/// Check if the main window is currently visible.
private func updateMainWindowVisibility() {
    isMainWindowVisible = NSApplication.shared.windows.contains {
        !($0 is NSPanel) && $0.isVisible &&
        ($0.title == "OpenWhisper" || $0.identifier?.rawValue == "main")
    }
}

/// Called when TTS settings change.
func onTTSSettingsChanged() {
    syncEchoModeState()
}

/// Called after a new transcription entry is added — triggers echo mode read.
private func echoNewEntry(_ entry: TranscriptionEntry) {
    guard echoModeState.isActive, !isMainWindowVisible else { return }
    echoModeController?.displayEntry(entry)
}
```

- [ ] **Step 5: Add Speechify pause to startRecording()**

In `startRecording()`, add the pause call at the **very beginning** of the method, before model readiness checks and permission checks (around line 228, right after `func startRecording() async {`). This ensures Speechify is paused even if recording is blocked by a missing model or permission:

```swift
// Pause Speechify if TTS is active (manual read or echo mode)
if TTSMode(rawValue: ttsMode) == .speechify {
    speechifyService.pausePlayback()
}
```

- [ ] **Step 6: Add echo mode trigger to stopRecordingAndTranscribe()**

In `stopRecordingAndTranscribe()`, after `historyStore.addEntry(entry)` (around line 461), add:

```swift
// Trigger Echo Mode read-aloud if active
echoNewEntry(entry)
```

- [ ] **Step 7: Build to verify everything compiles**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add OpenWhisper/AppState.swift OpenWhisper/AppDelegate.swift
git commit -m "feat(tts): wire Speechify and Echo Mode into AppState"
```

---

### Task 8: Settings View — Wire TTS Changes to AppState

**Files:**
- Modify: `OpenWhisper/Views/SettingsView.swift`

The settings UI was added in Task 4 but needs to notify AppState when TTS settings change so echo mode state stays in sync.

- [ ] **Step 1: Add onChange handlers to the TTS section**

In `SettingsView.swift`, add `.onChange` modifiers to the TTS Mode picker and Echo Mode toggle. After the `Section("Text to Speech")` closing brace, add:

```swift
.onChange(of: ttsMode) { _, newValue in
    appState.ttsMode = newValue  // explicitly sync @AppStorage on AppState
    appState.onTTSSettingsChanged()
}
.onChange(of: echoModeEnabled) { _, newValue in
    appState.echoModeEnabled = newValue  // explicitly sync
    appState.onTTSSettingsChanged()
}
.onChange(of: echoModeDockPosition) { _, newValue in
    appState.echoModeDockPosition = newValue  // explicitly sync
    appState.onTTSSettingsChanged()
    appState.echoModeController?.updateDockPosition(
        DockPosition(rawValue: newValue) ?? .bottom
    )
}
```

Note: These `.onChange` modifiers should be placed on the `Section` view, not inside it. The explicit assignment to `appState` properties is required because `@AppStorage` on non-View types does not auto-sync when another `@AppStorage` with the same key writes a new value.

- [ ] **Step 2: Build to verify**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/Views/SettingsView.swift
git commit -m "feat(tts): wire settings changes to AppState echo mode sync"
```

---

### Task 9: Regenerate Xcode Project and Full Build Verification

**Files:**
- None (project generation + build verification)

- [ ] **Step 1: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: "Generated project" message. New files in `OpenWhisper/TTS/` are auto-discovered.

- [ ] **Step 2: Run full build**

Run: `scripts/build.sh`
Expected: BUILD SUCCEEDED with no warnings related to TTS code.

- [ ] **Step 3: Verify file structure**

Confirm all new files exist:
```
OpenWhisper/TTS/TTSSettings.swift
OpenWhisper/TTS/SpeechifyService.swift
OpenWhisper/TTS/EchoModeState.swift
OpenWhisper/TTS/EchoModePanel.swift
OpenWhisper/TTS/EchoModePanelContent.swift
OpenWhisper/TTS/EchoModeController.swift
```

- [ ] **Step 4: Commit if any project file changes needed**

```bash
git status
# If project.yml or other generated files changed, commit them
```
