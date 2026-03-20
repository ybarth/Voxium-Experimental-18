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

enum TextInsertionMethod: String, CaseIterable {
    case paste
    case keyPresses
    case accessibility

    var displayName: String {
        switch self {
        case .paste: return "Paste (⌘V)"
        case .keyPresses: return "Key Presses"
        case .accessibility: return "Accessibility API"
        }
    }
}
