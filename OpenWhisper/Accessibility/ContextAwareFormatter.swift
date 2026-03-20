import Foundation

enum ContextAwareFormatter {

    static func format(_ text: String, context: AccessibilityContext?) -> String {
        guard let context, context.fieldType != .noTextField else {
            // No context: just trim whitespace (current behavior)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        switch context.fieldType {
        case .codeEditor, .terminal:
            // No formatting — insert literal text
            return result

        case .searchField, .urlBar:
            // Strip trailing periods, no leading space, no capitalization
            result = result.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return result

        case .plainText, .richText, .chatMessage, .unknown, .noTextField:
            // Apply smart formatting
            result = applySmartFormatting(result, context: context)
            return result
        }
    }

    private static func applySmartFormatting(_ text: String, context: AccessibilityContext) -> String {
        var result = text

        // Capitalize first letter if at beginning of text or after sentence-ending punctuation
        let shouldCapitalize: Bool
        if let before = context.textBeforeCursor {
            if before.isEmpty {
                shouldCapitalize = true
            } else {
                let trimmed = before.trimmingCharacters(in: .whitespaces)
                let lastChar = trimmed.last
                shouldCapitalize = lastChar == "." || lastChar == "!" || lastChar == "?" || lastChar == "\n"
            }
        } else {
            // No context about preceding text; assume start of field
            shouldCapitalize = true
        }

        if shouldCapitalize, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        // Add leading space if text before cursor ends with non-whitespace
        if let before = context.textBeforeCursor, !before.isEmpty {
            let lastChar = before.last!
            if !lastChar.isWhitespace && !lastChar.isNewline {
                result = " " + result
            }
        }

        return result
    }
}
