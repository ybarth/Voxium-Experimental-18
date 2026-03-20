import Foundation

struct AccessibilityContext {
    let bundleIdentifier: String?
    let applicationName: String?
    let fieldType: TextFieldType
    let textBeforeCursor: String?
    let textAfterCursor: String?
    let selectedText: String?
    let cursorScreenPoint: CGPoint?
    let capturedAt: Date

    enum TextFieldType: String, Codable {
        case plainText
        case richText
        case codeEditor
        case searchField
        case urlBar
        case terminal
        case chatMessage
        case unknown
        case noTextField
    }

    static let empty = AccessibilityContext(
        bundleIdentifier: nil,
        applicationName: nil,
        fieldType: .noTextField,
        textBeforeCursor: nil,
        textAfterCursor: nil,
        selectedText: nil,
        cursorScreenPoint: nil,
        capturedAt: Date()
    )
}
