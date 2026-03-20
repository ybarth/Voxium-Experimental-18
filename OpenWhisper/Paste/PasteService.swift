import AppKit
import Carbon.HIToolbox

@MainActor
final class PasteService {
    func paste(text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let previousContents = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        }
        let previousChangeCount = pasteboard.changeCount

        // Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after a delay
        let saved = previousContents
        let savedChangeCount = previousChangeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Only restore if our paste is still on the clipboard
            if pasteboard.changeCount == savedChangeCount + 1 {
                pasteboard.clearContents()
                if let saved {
                    for (typeRaw, data) in saved {
                        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(typeRaw))
                    }
                }
            }
        }
    }

    /// Insert text directly via accessibility API, falling back to clipboard paste.
    func paste(text: String, context: AccessibilityContext?) {
        guard let context, context.fieldType != .noTextField else {
            paste(text: text)
            return
        }

        // Try direct insertion via AX API
        if tryDirectInsertion(text: text) {
            return
        }

        // Fallback to clipboard paste
        paste(text: text)
    }

    // MARK: - Direct insertion

    private func tryDirectInsertion(text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAppValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppValue) == .success,
              let focusedApp = focusedAppValue else { return false }

        let appElement = focusedApp as! AXUIElement

        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue else { return false }

        let element = focused as! AXUIElement

        // Try setting selected text attribute (replaces selection or inserts at cursor)
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return result == .success
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
