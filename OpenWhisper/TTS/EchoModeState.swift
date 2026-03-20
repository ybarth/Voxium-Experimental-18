import AppKit

@MainActor
@Observable
final class EchoModeState {
    var isActive: Bool = false
    var dockPosition: DockPosition = .bottom
    var currentEntry: TranscriptionEntry?
    /// Tracks user's drag position to persist across hide/show cycles.
    var lastUserPosition: NSPoint? = nil
}
