import AppKit

final class EchoModePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Must be true so the NSTextView inside can become first responder
    // and Speechify can read selected text via Accessibility API.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
