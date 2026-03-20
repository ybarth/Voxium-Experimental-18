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
