import AppKit
import Carbon.HIToolbox

@MainActor
final class KeyPressInsertionService {
    private let logger = TranscriptionLogger.shared

    /// Insert text by simulating individual key presses via CGEvent.
    /// Uses keyboardSetUnicodeString to handle arbitrary Unicode characters
    /// without needing a keycode lookup table.
    func insert(text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            logger.error("KeyPress insertion: failed to create CGEventSource", category: .tts)
            return
        }

        for char in text {
            if char == "\n" || char == "\r" {
                postKey(source: source, virtualKey: CGKeyCode(kVK_Return))
            } else if char == "\t" {
                postKey(source: source, virtualKey: CGKeyCode(kVK_Tab))
            } else {
                // Use a dummy virtual key (0) and set the Unicode string directly
                var chars = Array(char.utf16)
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { continue }
                keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                keyDown.post(tap: .cghidEventTap)

                guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
                keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                keyUp.post(tap: .cghidEventTap)
            }
        }

        logger.info("KeyPress insertion: typed \(text.count) characters", category: .tts)
    }

    private func postKey(source: CGEventSource, virtualKey: CGKeyCode) {
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        keyUp?.post(tap: .cghidEventTap)
    }
}
