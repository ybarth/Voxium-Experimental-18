import ApplicationServices

enum TextFieldAnalyzer {
    // Known bundle IDs by category
    private static let codeEditors: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "dev.zed.Zed",
    ]

    private static let terminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "io.alacritty",
        "com.mitchellh.ghostty",
    ]

    private static let browsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
    ]

    private static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS",
        "com.hnc.Discord",
        "com.facebook.archon",  // Messenger
        "ru.keepcoder.Telegram",
    ]

    static func classify(element: AXUIElement, bundleIdentifier: String?) -> AccessibilityContext.TextFieldType {
        guard let bundleID = bundleIdentifier else { return .unknown }

        // Terminal apps
        if terminals.contains(bundleID) {
            return .terminal
        }

        // Code editors
        if codeEditors.contains(bundleID) {
            return .codeEditor
        }

        // Chat apps
        if chatApps.contains(bundleID) {
            return .chatMessage
        }

        // Browser: check for URL bar vs search vs regular text
        if browsers.contains(bundleID) {
            return classifyBrowserElement(element, bundleID: bundleID)
        }

        // Classify by AX role/subrole
        return classifyByRole(element)
    }

    private static func classifyBrowserElement(_ element: AXUIElement, bundleID: String) -> AccessibilityContext.TextFieldType {
        let role = axStringAttribute(element, kAXRoleAttribute)
        let subrole = axStringAttribute(element, kAXSubroleAttribute)

        // URL bar is typically a text field with "AXURLField" subrole or specific identifiers
        if subrole == "AXSearchField" || subrole == "AXURLField" {
            return .urlBar
        }

        if role == kAXTextFieldRole {
            // In Safari, the address bar uses a combo box or text field
            let desc = axStringAttribute(element, kAXDescriptionAttribute)
            if let desc, desc.lowercased().contains("address") || desc.lowercased().contains("url") || desc.lowercased().contains("search") {
                return .searchField
            }
            return .searchField  // Default browser text fields are often search
        }

        if role == kAXTextAreaRole || role == "AXWebArea" {
            return .plainText
        }

        return .unknown
    }

    private static func classifyByRole(_ element: AXUIElement) -> AccessibilityContext.TextFieldType {
        let role = axStringAttribute(element, kAXRoleAttribute)
        let subrole = axStringAttribute(element, kAXSubroleAttribute)

        if subrole == "AXSearchField" {
            return .searchField
        }

        switch role {
        case kAXTextAreaRole:
            return .plainText
        case kAXTextFieldRole:
            return .plainText
        case "AXWebArea":
            return .richText
        default:
            return .unknown
        }
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
