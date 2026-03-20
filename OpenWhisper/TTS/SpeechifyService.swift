import AppKit
import Carbon.HIToolbox

@MainActor
final class SpeechifyService {
    private let logger = TranscriptionLogger.shared

    /// Simulate § key (kVK_ISO_Section) to trigger Speechify read.
    func triggerRead() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            logger.error("Failed to create CGEventSource for triggerRead", category: .tts)
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ISO_Section), keyDown: true)
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ISO_Section), keyDown: false)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Simulate Shift+§ to pause Speechify.
    func pausePlayback() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            logger.error("Failed to create CGEventSource for pausePlayback", category: .tts)
            return
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ISO_Section), keyDown: true)
        keyDown?.flags = .maskShift
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ISO_Section), keyDown: false)
        keyUp?.flags = .maskShift
        keyUp?.post(tap: .cghidEventTap)
    }
}
