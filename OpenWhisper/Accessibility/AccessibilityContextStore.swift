import Foundation

struct AccessibilityContextSnapshot: Identifiable {
    let id = UUID()
    let context: AccessibilityContext
    let formattingApplied: String?  // description of what formatting was applied, if any

    var displayName: String {
        if let name = context.applicationName {
            return name
        }
        if let bundleID = context.bundleIdentifier {
            return bundleID
        }
        return "Unknown"
    }
}

@MainActor
@Observable
final class AccessibilityContextStore {
    /// The most recently captured context (live — updates on each recording start).
    var currentContext: AccessibilityContextSnapshot?

    /// History of past contexts, newest first.
    private(set) var history: [AccessibilityContextSnapshot] = []

    /// Maximum number of context snapshots to keep. Configurable 10–100, default 10.
    var maxHistoryCount: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "maxContextHistoryCount")
            return stored > 0 ? min(max(stored, 10), 100) : 10
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 10), 100), forKey: "maxContextHistoryCount")
        }
    }

    /// Record a new context capture. Pushes the previous current into history.
    func recordContext(_ context: AccessibilityContext, formattingApplied: String? = nil) {
        // Move previous current to history
        if let previous = currentContext {
            history.insert(previous, at: 0)
            // Prune history
            if history.count > maxHistoryCount {
                history = Array(history.prefix(maxHistoryCount))
            }
        }

        currentContext = AccessibilityContextSnapshot(
            context: context,
            formattingApplied: formattingApplied
        )
    }

    func clearHistory() {
        history.removeAll()
    }
}
