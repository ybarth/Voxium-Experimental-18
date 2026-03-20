import AppKit
import ApplicationServices

@MainActor
final class CursorPositionService {
    private let logger = TranscriptionLogger.shared

    func captureContext() -> AccessibilityContext {
        let systemWide = AXUIElementCreateSystemWide()

        // Get focused application
        var focusedAppValue: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppValue)
        guard appResult == .success, let focusedApp = focusedAppValue else {
            return .empty
        }

        let appElement = focusedApp as! AXUIElement

        // Get app info
        let appName = stringAttribute(appElement, kAXTitleAttribute)
        let bundleID = pidToBundleID(appElement)

        // Get focused element
        var focusedValue: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard focusResult == .success, let focusedElement = focusedValue else {
            return AccessibilityContext(
                bundleIdentifier: bundleID,
                applicationName: appName,
                fieldType: .noTextField,
                textBeforeCursor: nil,
                textAfterCursor: nil,
                selectedText: nil,
                cursorScreenPoint: nil,
                capturedAt: Date()
            )
        }

        let element = focusedElement as! AXUIElement

        // Find text element
        let textElement = findTextElement(element)
        let fieldType = TextFieldAnalyzer.classify(element: textElement ?? element, bundleIdentifier: bundleID)

        var textBefore: String?
        var textAfter: String?
        var selectedText: String?
        var cursorPoint: CGPoint?

        if let textEl = textElement {
            // Get value (full text)
            let fullText = stringAttribute(textEl, kAXValueAttribute)

            // Get selected text range for cursor position
            var rangeValue: AnyObject?
            if AXUIElementCopyAttributeValue(textEl, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
               let rangeRef = rangeValue {
                var range = CFRange()
                if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), let text = fullText {
                    let nsText = text as NSString

                    // Text before cursor (last ~200 chars)
                    let beforeEnd = range.location
                    let beforeStart = max(0, beforeEnd - 200)
                    if beforeEnd > 0, beforeEnd <= nsText.length {
                        textBefore = nsText.substring(with: NSRange(location: beforeStart, length: beforeEnd - beforeStart))
                    }

                    // Text after cursor (first ~50 chars)
                    let afterStart = range.location + range.length
                    let afterEnd = min(nsText.length, afterStart + 50)
                    if afterStart < nsText.length {
                        textAfter = nsText.substring(with: NSRange(location: afterStart, length: afterEnd - afterStart))
                    }

                    // Selected text
                    if range.length > 0, range.location + range.length <= nsText.length {
                        selectedText = nsText.substring(with: NSRange(location: range.location, length: range.length))
                    }
                }

                // Cursor screen position
                var boundsValue: AnyObject?
                if AXUIElementCopyParameterizedAttributeValue(
                    textEl,
                    kAXBoundsForRangeParameterizedAttribute as CFString,
                    rangeRef,
                    &boundsValue
                ) == .success, let boundsRef = boundsValue {
                    var rect = CGRect.zero
                    if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) {
                        cursorPoint = CGPoint(x: rect.midX, y: rect.midY)
                    }
                }
            }
        }

        return AccessibilityContext(
            bundleIdentifier: bundleID,
            applicationName: appName,
            fieldType: fieldType,
            textBeforeCursor: textBefore,
            textAfterCursor: textAfter,
            selectedText: selectedText,
            cursorScreenPoint: cursorPoint,
            capturedAt: Date()
        )
    }

    // MARK: - Text element detection

    private func findTextElement(_ element: AXUIElement) -> AXUIElement? {
        // Strategy 1: Check if the focused element itself is a text field
        if isTextElement(element) {
            return element
        }

        // Strategy 2: Walk parent hierarchy (max 5 levels)
        var current = element
        for _ in 0..<5 {
            var parentValue: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parent = parentValue else { break }
            let parentElement = parent as! AXUIElement
            if isTextElement(parentElement) {
                return parentElement
            }
            current = parentElement
        }

        // Strategy 3: Search children of focused element
        if let child = findTextChild(element, depth: 2) {
            return child
        }

        // Fallback: use focused element if it has a value
        if stringAttribute(element, kAXValueAttribute) != nil {
            return element
        }

        return nil
    }

    private func findTextChild(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }

        for child in children.prefix(10) {
            if isTextElement(child) {
                return child
            }
        }

        for child in children.prefix(5) {
            if let found = findTextChild(child, depth: depth - 1) {
                return found
            }
        }

        return nil
    }

    private func isTextElement(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(element, kAXRoleAttribute) else { return false }
        let textRoles: Set<String> = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXWebArea"
        ]
        return textRoles.contains(role)
    }

    // MARK: - Helpers

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func pidToBundleID(_ appElement: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
