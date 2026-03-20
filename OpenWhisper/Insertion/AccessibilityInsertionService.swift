import AppKit
import ApplicationServices

/// Result of an accessibility-based text insertion attempt.
enum InsertionResult {
    /// Text was successfully inserted via AX API. Includes the element and the range of inserted text.
    case success(element: AXUIElement, insertedRange: CFRange)
    /// AX insertion failed — caller should fall back to paste.
    case fallbackToPaste
}

@MainActor
final class AccessibilityInsertionService {
    private let logger = TranscriptionLogger.shared

    /// Insert text at the cursor position in the focused text field via Accessibility API.
    /// Returns the insertion result for echo mode integration.
    func insert(text: String) -> InsertionResult {
        guard let state = captureAXState() else {
            logger.info("AX insertion: no valid text field found, falling back to paste", category: .tts)
            return .fallbackToPaste
        }

        let currentText = state.text
        let nsString = currentText as NSString

        // Clamp cursor position to valid range
        let safeLocation = min(state.cursorLocation, nsString.length)
        let safeLength = min(state.selectionLength, nsString.length - safeLocation)
        let nsRange = NSRange(location: safeLocation, length: safeLength)

        // Convert UTF-16 NSRange to Swift String.Index range
        guard let swiftRange = Range(nsRange, in: currentText) else {
            logger.error("AX insertion: failed to convert NSRange to String.Index", category: .tts)
            return .fallbackToPaste
        }

        // Build new text with insertion
        var newText = currentText
        newText.replaceSubrange(swiftRange, with: text)

        // Set the new value
        let setResult = AXUIElementSetAttributeValue(
            state.element,
            kAXValueAttribute as CFString,
            newText as CFTypeRef
        )

        guard setResult == .success else {
            logger.error("AX insertion: setValue failed (\(setResult.rawValue))", category: .tts)
            return .fallbackToPaste
        }

        // Calculate the inserted text range (UTF-16 offsets)
        let insertedLength = (text as NSString).length
        let insertedRange = CFRange(location: safeLocation, length: insertedLength)

        // Position cursor at end of inserted text
        let newCursorLocation = safeLocation + insertedLength
        setCursorPosition(element: state.element, location: newCursorLocation)

        logger.info("AX insertion: inserted \(text.count) chars at position \(safeLocation)", category: .tts)
        return .success(element: state.element, insertedRange: insertedRange)
    }

    /// Select a text range in the given AX element (for echo mode Speechify integration).
    func selectRange(element: AXUIElement, range: CFRange) {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            logger.error("AX selectRange: failed to create AXValue", category: .tts)
            return
        }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        if result != .success {
            logger.error("AX selectRange: failed (\(result.rawValue))", category: .tts)
        }
    }

    // MARK: - Private

    private struct AXTextFieldState {
        let element: AXUIElement
        let text: String
        let cursorLocation: Int   // UTF-16 offset
        let selectionLength: Int  // UTF-16 offset
    }

    private func captureAXState() -> AXTextFieldState? {
        let systemWide = AXUIElementCreateSystemWide()

        // Get focused application
        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let app = focusedApp else {
            return nil
        }

        // Get focused element
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else {
            return nil
        }

        let axElement = element as! AXUIElement

        // Validate it's a text field
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else {
            return nil
        }

        let validRoles = [kAXTextFieldRole, kAXTextAreaRole, "AXWebArea", "AXComboBox"]
        guard validRoles.contains(role) else {
            return nil
        }

        // Get current text value
        var currentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue) == .success,
              let currentText = currentValue as? String else {
            return nil
        }

        // Get cursor position / selection range (UTF-16 offsets)
        var selectedRange: CFTypeRef?
        let nsString = currentText as NSString
        var cursorLocation = nsString.length
        var selectionLength = 0

        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success,
           let rangeValue = selectedRange {
            var range = CFRange()
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
            cursorLocation = min(range.location, nsString.length)
            selectionLength = min(range.length, nsString.length - cursorLocation)
        }

        return AXTextFieldState(
            element: axElement,
            text: currentText,
            cursorLocation: cursorLocation,
            selectionLength: selectionLength
        )
    }

    private func setCursorPosition(element: AXUIElement, location: Int, attempt: Int = 1) {
        var newRange = CFRange(location: location, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &newRange) else { return }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )

        if result == .success {
            logger.debug("AX cursor positioned at \(location) (attempt \(attempt))", category: .tts)
        } else if attempt < 5 {
            let delay = Double(attempt * attempt) * 0.01
            nonisolated(unsafe) let capturedElement = element
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                self.setCursorPosition(element: capturedElement, location: location, attempt: attempt + 1)
            }
        } else {
            logger.error("AX cursor positioning failed after \(attempt) attempts", category: .tts)
        }
    }
}
